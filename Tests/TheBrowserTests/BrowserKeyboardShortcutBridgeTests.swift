import AppKit
import Testing

@Test func layoutIndependentBridgeIgnoresShortcutsThatAlreadyMatchCurrentLayout() {
    let command = BrowserKeyboardShortcutBridge.commandForLayoutIndependentDispatch(
        keyCode: 8,
        modifierFlags: [.command],
        charactersIgnoringModifiers: "c"
    )

    #expect(command == nil)
}

@Test func layoutIndependentBridgeMapsSelectAllWhenPhysicalShortcutDoesNotMatchLayout() {
    let command = BrowserKeyboardShortcutBridge.commandForLayoutIndependentDispatch(
        keyCode: 0,
        modifierFlags: [.command],
        charactersIgnoringModifiers: "u"
    )

    #expect(command == .selectAll)
}

@Test func layoutIndependentBridgeMapsPasteWhenPhysicalShortcutDoesNotMatchLayout() {
    let command = BrowserKeyboardShortcutBridge.commandForLayoutIndependentDispatch(
        keyCode: 9,
        modifierFlags: [.command],
        charactersIgnoringModifiers: "m"
    )

    #expect(command == .paste)
}

@Test func layoutIndependentBridgeMapsPasteAndMatchStyleWhenPhysicalShortcutDoesNotMatchLayout() {
    let command = BrowserKeyboardShortcutBridge.commandForLayoutIndependentDispatch(
        keyCode: 9,
        modifierFlags: [.command, .shift],
        charactersIgnoringModifiers: "M"
    )

    #expect(command == .pasteAndMatchStyle)
}

@Test func layoutIndependentBridgeMapsBrowserCommandsFromPhysicalKeys() {
    let settingsCommand = BrowserKeyboardShortcutBridge.commandForLayoutIndependentDispatch(
        keyCode: 43,
        modifierFlags: [.command],
        charactersIgnoringModifiers: "б"
    )
    let setAsDefaultBrowserCommand = BrowserKeyboardShortcutBridge.commandForLayoutIndependentDispatch(
        keyCode: 2,
        modifierFlags: [.command],
        charactersIgnoringModifiers: "в"
    )
    let newTabCommand = BrowserKeyboardShortcutBridge.commandForLayoutIndependentDispatch(
        keyCode: 17,
        modifierFlags: [.command],
        charactersIgnoringModifiers: "e"
    )
    let openHistoryCommand = BrowserKeyboardShortcutBridge.commandForLayoutIndependentDispatch(
        keyCode: 16,
        modifierFlags: [.command],
        charactersIgnoringModifiers: "н"
    )
    let archiveTabCommand = BrowserKeyboardShortcutBridge.commandForLayoutIndependentDispatch(
        keyCode: 13,
        modifierFlags: [.command],
        charactersIgnoringModifiers: "ц"
    )
    let savePageCommand = BrowserKeyboardShortcutBridge.commandForLayoutIndependentDispatch(
        keyCode: 1,
        modifierFlags: [.command, .shift],
        charactersIgnoringModifiers: "w"
    )
    let printPageCommand = BrowserKeyboardShortcutBridge.commandForLayoutIndependentDispatch(
        keyCode: 35,
        modifierFlags: [.command],
        charactersIgnoringModifiers: "з"
    )
    let copyLinkCommand = BrowserKeyboardShortcutBridge.commandForLayoutIndependentDispatch(
        keyCode: 8,
        modifierFlags: [.command, .shift],
        charactersIgnoringModifiers: "с"
    )
    let findInPageCommand = BrowserKeyboardShortcutBridge.commandForLayoutIndependentDispatch(
        keyCode: 3,
        modifierFlags: [.command],
        charactersIgnoringModifiers: "а"
    )
    let findAndReplaceCommand = BrowserKeyboardShortcutBridge.commandForLayoutIndependentDispatch(
        keyCode: 3,
        modifierFlags: [.command, .option],
        charactersIgnoringModifiers: "а"
    )
    let findNextCommand = BrowserKeyboardShortcutBridge.commandForLayoutIndependentDispatch(
        keyCode: 5,
        modifierFlags: [.command],
        charactersIgnoringModifiers: "п"
    )
    let findPreviousCommand = BrowserKeyboardShortcutBridge.commandForLayoutIndependentDispatch(
        keyCode: 5,
        modifierFlags: [.command, .shift],
        charactersIgnoringModifiers: "П"
    )
    let jumpToSelectionCommand = BrowserKeyboardShortcutBridge.commandForLayoutIndependentDispatch(
        keyCode: 38,
        modifierFlags: [.command],
        charactersIgnoringModifiers: "о"
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
    #expect(setAsDefaultBrowserCommand == .setAsDefaultBrowser)
    #expect(newTabCommand == .newTab)
    #expect(openHistoryCommand == .openHistory)
    #expect(archiveTabCommand == .archiveTab)
    #expect(savePageCommand == .savePage)
    #expect(printPageCommand == .printPage)
    #expect(copyLinkCommand == .copyLink)
    #expect(findInPageCommand == .findInPage)
    #expect(findAndReplaceCommand == .findAndReplace)
    #expect(findNextCommand == .findNextInPage)
    #expect(findPreviousCommand == .findPreviousInPage)
    #expect(jumpToSelectionCommand == .jumpToSelection)
    #expect(clearTemporaryTabsCommand == .clearTemporaryTabs)
    #expect(goBackCommand == .goBack)
}

@Test func browserSpaceShortcutsMapControlNumberRowKeys() {
    #expect(BrowserSpaceShortcuts.spaceIndex(forPhysicalKeyCode: 18, modifierFlags: [.control]) == 0)
    #expect(BrowserSpaceShortcuts.spaceIndex(forPhysicalKeyCode: 19, modifierFlags: [.control]) == 1)
    #expect(BrowserSpaceShortcuts.spaceIndex(forPhysicalKeyCode: 20, modifierFlags: [.control]) == 2)
    #expect(BrowserSpaceShortcuts.spaceIndex(forPhysicalKeyCode: 21, modifierFlags: [.control]) == 3)
    #expect(BrowserSpaceShortcuts.spaceIndex(forPhysicalKeyCode: 18, modifierFlags: [.command]) == nil)
    #expect(BrowserSpaceShortcuts.shortcut(forSpaceIndex: 0) == BrowserKeyboardShortcut("1", modifiers: [.control]))
    #expect(BrowserSpaceShortcuts.shortcut(forSpaceIndex: 4) == nil)
}
