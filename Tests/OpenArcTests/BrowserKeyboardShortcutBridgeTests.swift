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
    let toggleBookmarkCommand = BrowserKeyboardShortcutBridge.commandForLayoutIndependentDispatch(
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
    #expect(toggleBookmarkCommand == .toggleBookmark)
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

@Test func splitViewShortcutsUseArcDefaultsAndDispatchFromPhysicalKeys() {
    #expect(BrowserCommands.addSplitView.shortcut == BrowserKeyboardShortcut("=", modifiers: [.control, .shift]))
    #expect(BrowserCommands.closeSplitPane.shortcut == BrowserKeyboardShortcut("-", modifiers: [.control, .shift]))
    // Shift turns the keys into "+" and "_", so menu key equivalents alone do not match them.
    #expect(BrowserKeyboardShortcutBridge.commandForLayoutIndependentDispatch(
        keyCode: 24,
        modifierFlags: [.control, .shift],
        charactersIgnoringModifiers: "+"
    ) == .addSplitView)
    #expect(BrowserKeyboardShortcutBridge.commandForLayoutIndependentDispatch(
        keyCode: 27,
        modifierFlags: [.control, .shift],
        charactersIgnoringModifiers: "_"
    ) == .closeSplitPane)
    #expect(BrowserKeyboardShortcutBridge.commandForLayoutIndependentDispatch(
        keyCode: 24,
        modifierFlags: [.shift],
        charactersIgnoringModifiers: "+"
    ) == nil, "Typing + is not a command")
    #expect(BrowserKeyboardShortcutBridge.commandForLayoutIndependentDispatch(
        keyCode: 24,
        modifierFlags: [.command, .shift],
        charactersIgnoringModifiers: "+"
    ) == nil, "Cmd-Shift-= is Zoom In, not a split command")
}

@Test func splitPaneShortcutsUseArcDefaultsAndDispatchFromPhysicalKeys() {
    #expect(BrowserCommands.focusSplitPane1.shortcut == BrowserKeyboardShortcut("1", modifiers: [.control, .shift]))
    #expect(BrowserCommands.focusNextSplitPane.shortcut == BrowserKeyboardShortcut("]", modifiers: [.control, .shift]))
    // Shift turns 1 into "!" and ] into "}".
    #expect(BrowserKeyboardShortcutBridge.commandForLayoutIndependentDispatch(
        keyCode: 18,
        modifierFlags: [.control, .shift],
        charactersIgnoringModifiers: "!"
    ) == .focusSplitPane1)
    #expect(BrowserKeyboardShortcutBridge.commandForLayoutIndependentDispatch(
        keyCode: 21,
        modifierFlags: [.control, .shift],
        charactersIgnoringModifiers: "$"
    ) == .focusSplitPane4)
    #expect(BrowserKeyboardShortcutBridge.commandForLayoutIndependentDispatch(
        keyCode: 30,
        modifierFlags: [.control, .shift],
        charactersIgnoringModifiers: "}"
    ) == .focusNextSplitPane)
    #expect(BrowserKeyboardShortcutBridge.commandForLayoutIndependentDispatch(
        keyCode: 33,
        modifierFlags: [.control, .shift],
        charactersIgnoringModifiers: "{"
    ) == .focusPreviousSplitPane)
    #expect(BrowserSpaceShortcuts.spaceIndex(forPhysicalKeyCode: 18, modifierFlags: [.control, .shift]) == nil)
}

@Test func standardWindowShortcutsWorkFromPhysicalKeysAndStayReserved() throws {
    #expect(BrowserKeyboardShortcutBridge.commandForLayoutIndependentDispatch(
        keyCode: 4,
        modifierFlags: [.command],
        charactersIgnoringModifiers: "р"
    ) == .hideApplication)
    #expect(BrowserKeyboardShortcutBridge.commandForLayoutIndependentDispatch(
        keyCode: 4,
        modifierFlags: [.command, .option],
        charactersIgnoringModifiers: "р"
    ) == .hideOtherApplications)
    #expect(BrowserKeyboardShortcutBridge.commandForLayoutIndependentDispatch(
        keyCode: 46,
        modifierFlags: [.command],
        charactersIgnoringModifiers: "ь"
    ) == .minimizeWindow)
    #expect(BrowserKeyboardShortcutBridge.commandForLayoutIndependentDispatch(
        keyCode: 13,
        modifierFlags: [.command, .shift],
        charactersIgnoringModifiers: "Ц"
    ) == .closeWindow)
    #expect(BrowserKeyboardShortcutBridge.commandForLayoutIndependentDispatch(
        keyCode: 13,
        modifierFlags: [.command],
        charactersIgnoringModifiers: "ц"
    ) == .archiveTab, "Command-W still archives the tab")

    let suiteName = "OpenArcTests.\(UUID().uuidString)"
    let userDefaults = try #require(UserDefaults(suiteName: suiteName))
    defer { userDefaults.removePersistentDomain(forName: suiteName) }
    let store = BrowserShortcutStore(userDefaults: userDefaults)
    #expect(store.conflictDescription(for: BrowserKeyboardShortcut("m"), excluding: nil) == BrowserStrings.menuMinimize)
    #expect(!store.setShortcut(BrowserKeyboardShortcut("w", modifiers: [.command, .shift]), for: .openHistory))
}

@Test func aKeyTheUserGaveACommandBeatsALaterReservedWindowKey() throws {
    let suiteName = "OpenArcTests.\(UUID().uuidString)"
    let userDefaults = try #require(UserDefaults(suiteName: suiteName))
    defer { userDefaults.removePersistentDomain(forName: suiteName) }
    // Saved before Command-M became Minimize.
    let saved = try JSONEncoder().encode(["openHistory": BrowserKeyboardShortcut("m")])
    userDefaults.set(saved, forKey: "browser.settings.shortcutOverrides")
    let store = BrowserShortcutStore(userDefaults: userDefaults)
    #expect(store.command(using: BrowserKeyboardShortcut("m")) == .openHistory)
    #expect(BrowserKeyboardShortcutBridge.commandForLayoutIndependentDispatch(
        keyCode: 46,
        modifierFlags: [.command],
        charactersIgnoringModifiers: "ь",
        shortcutResolver: store
    ) == .openHistory)
}
