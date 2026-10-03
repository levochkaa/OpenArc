import AppKit
import Foundation

// MARK: - BrowserKeyboardShortcut

struct BrowserKeyboardShortcut: Codable, Equatable, Hashable {
    // MARK: Lifecycle

    init(_ keyEquivalent: String, modifiers: NSEvent.ModifierFlags = [.command]) {
        self.keyEquivalent = keyEquivalent
        self.modifiers = modifiers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.keyEquivalent = try container.decode(String.self, forKey: .keyEquivalent)
        let modifiersRawValue = try container.decode(NSEvent.ModifierFlags.RawValue.self, forKey: .modifiersRawValue)
        self.modifiers = NSEvent.ModifierFlags(rawValue: modifiersRawValue)
    }

    // MARK: Internal

    static let unassigned = BrowserKeyboardShortcut("", modifiers: [])

    let keyEquivalent: String
    let modifiers: NSEvent.ModifierFlags

    var isAssigned: Bool {
        !keyEquivalent.isEmpty
    }

    var keyCaps: [String] {
        var result = [String]()

        if modifiers.contains(.control) {
            result.append("\u{2303}")
        }

        if modifiers.contains(.option) {
            result.append("\u{2325}")
        }

        if modifiers.contains(.shift) {
            result.append("\u{21E7}")
        }

        if modifiers.contains(.command) {
            result.append("\u{2318}")
        }

        result.append(keyEquivalent.uppercased())
        return result
    }

    var displayText: String {
        keyCaps.joined()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(keyEquivalent, forKey: .keyEquivalent)
        try container.encode(modifiers.rawValue, forKey: .modifiersRawValue)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(keyEquivalent)
        hasher.combine(modifiers.rawValue)
    }

    // MARK: Private

    private enum CodingKeys: String, CodingKey {
        case keyEquivalent
        case modifiersRawValue
    }
}

// MARK: - BrowserCommandDescriptor

struct BrowserCommandDescriptor {
    let menuTitle: String
    let helpTitle: String
    let shortcut: BrowserKeyboardShortcut
}

// MARK: - BrowserCommands

enum BrowserCommands {
    static let openSettings = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuSettings,
        helpTitle: BrowserStrings.menuSettings,
        shortcut: BrowserKeyboardShortcut(",")
    )

    static let setAsDefaultBrowser = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuSetAsDefaultBrowser,
        helpTitle: BrowserStrings.menuSetAsDefaultBrowser,
        shortcut: BrowserKeyboardShortcut("♡")
    )

    static let newTab = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuNewTab,
        helpTitle: BrowserStrings.sidebarNewTab,
        shortcut: BrowserKeyboardShortcut("t")
    )

    static let newIncognitoWindow = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuNewIncognitoWindow,
        helpTitle: BrowserStrings.menuNewIncognitoWindow,
        shortcut: BrowserKeyboardShortcut("n", modifiers: [.command, .shift])
    )

    static let openHistory = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuHistory,
        helpTitle: BrowserStrings.menuHistory,
        shortcut: BrowserKeyboardShortcut("y")
    )

    static let toggleBookmark = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.bookmarksAddCurrentPage,
        helpTitle: BrowserStrings.bookmarksAddCurrentPage,
        shortcut: BrowserKeyboardShortcut("d")
    )

    static let archiveTab = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.tabArchiveAction,
        helpTitle: BrowserStrings.tabArchiveTooltip,
        shortcut: BrowserKeyboardShortcut("w")
    )

    static let viewArchive = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.archiveViewAction,
        helpTitle: BrowserStrings.archiveViewAction,
        shortcut: .unassigned
    )

    static let clearArchive = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.archiveClear,
        helpTitle: BrowserStrings.archiveClear,
        shortcut: .unassigned
    )

    static let savePage = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuSavePageAs,
        helpTitle: BrowserStrings.menuSavePageAs,
        shortcut: BrowserKeyboardShortcut("s", modifiers: [.command, .shift])
    )

    static let printPage = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuPrint,
        helpTitle: BrowserStrings.menuPrint,
        shortcut: BrowserKeyboardShortcut("p")
    )

    static let copyLink = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.tabCopyLinkAction,
        helpTitle: BrowserStrings.tabCopyLinkAction,
        shortcut: BrowserKeyboardShortcut("c", modifiers: [.command, .shift])
    )

    static let findInPage = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuFind,
        helpTitle: BrowserStrings.menuFind,
        shortcut: BrowserKeyboardShortcut("f")
    )

    static let findAndReplace = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuFindAndReplace,
        helpTitle: BrowserStrings.menuFindAndReplace,
        shortcut: BrowserKeyboardShortcut("f", modifiers: [.command, .option])
    )

    static let findNext = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuFindNext,
        helpTitle: BrowserStrings.menuFindNext,
        shortcut: BrowserKeyboardShortcut("g")
    )

    static let findPrevious = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuFindPrevious,
        helpTitle: BrowserStrings.menuFindPrevious,
        shortcut: BrowserKeyboardShortcut("g", modifiers: [.command, .shift])
    )

    static let jumpToSelection = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuJumpToSelection,
        helpTitle: BrowserStrings.menuJumpToSelection,
        shortcut: BrowserKeyboardShortcut("j")
    )

    static let clearTemporaryTabs = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuClearTemporaryTabs,
        helpTitle: BrowserStrings.sidebarClearTemporaryTabsTooltip,
        shortcut: BrowserKeyboardShortcut("k", modifiers: [.command, .shift])
    )

    static let goBack = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.navigationBack,
        helpTitle: BrowserStrings.navigationBack,
        shortcut: BrowserKeyboardShortcut("[")
    )

    static let goForward = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.navigationForward,
        helpTitle: BrowserStrings.navigationForward,
        shortcut: BrowserKeyboardShortcut("]")
    )

    static let reload = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.navigationRefresh,
        helpTitle: BrowserStrings.navigationRefresh,
        shortcut: BrowserKeyboardShortcut("r")
    )

    static let forceReload = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuForceRefresh,
        helpTitle: BrowserStrings.menuForceRefresh,
        shortcut: BrowserKeyboardShortcut("r", modifiers: [.command, .shift])
    )

    static let clearCacheAndRefresh = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuClearCacheAndRefresh,
        helpTitle: BrowserStrings.menuClearCacheAndRefresh,
        shortcut: .unassigned
    )

    static let clearCookiesAndRefresh = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuClearCookiesAndRefresh,
        helpTitle: BrowserStrings.menuClearCookiesAndRefresh,
        shortcut: .unassigned
    )

    static let toggleSidebar = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuToggleSidebar,
        helpTitle: BrowserStrings.sidebarHide,
        shortcut: BrowserKeyboardShortcut("s")
    )

    static let toggleBookmarksBar = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.settingsShowBookmarksBar,
        helpTitle: BrowserStrings.settingsShowBookmarksBar,
        shortcut: BrowserKeyboardShortcut("b", modifiers: [.command, .shift])
    )
}

// MARK: - BrowserSpaceShortcuts

enum BrowserSpaceShortcuts {
    static let maximumIndexedSpaces = 4

    static func shortcut(forSpaceIndex index: Int) -> BrowserKeyboardShortcut? {
        guard (0..<maximumIndexedSpaces).contains(index) else {
            return nil
        }

        return BrowserKeyboardShortcut("\(index + 1)", modifiers: [.control])
    }

    static func spaceIndex(forPhysicalKeyCode keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) -> Int? {
        guard modifierFlags.intersection(.deviceIndependentFlagsMask) == [.control] else {
            return nil
        }

        switch keyCode {
        case 18:
            return 0
        case 19:
            return 1
        case 20:
            return 2
        case 21:
            return 3
        default:
            return nil
        }
    }
}

// MARK: - BrowserLayoutIndependentShortcutCommand

enum BrowserLayoutIndependentShortcutCommand: Equatable {
    case undo
    case redo
    case cut
    case copy
    case paste
    case pasteAndMatchStyle
    case selectAll
    case quit
    case openSettings
    case setAsDefaultBrowser
    case newTab
    case newIncognitoWindow
    case openHistory
    case toggleBookmark
    case archiveTab
    case viewArchive
    case clearArchive
    case savePage
    case printPage
    case copyLink
    case findInPage
    case findAndReplace
    case findNextInPage
    case findPreviousInPage
    case jumpToSelection
    case clearTemporaryTabs
    case goBack
    case goForward
    case reload
    case forceReload
    case clearCacheAndRefresh
    case clearCookiesAndRefresh
    case toggleSidebar
    case toggleBookmarksBar
}

// MARK: - BrowserKeyboardShortcutBridge

enum BrowserKeyboardShortcutBridge {
    // MARK: Internal

    static func commandForLayoutIndependentDispatch(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        charactersIgnoringModifiers: String?,
        shortcutResolver: BrowserShortcutResolving? = nil
    ) -> BrowserLayoutIndependentShortcutCommand? {
        let normalizedModifiers = modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard normalizedModifiers.contains(.command) else {
            return nil
        }

        guard let usKeyEquivalent = usKeyEquivalent(for: keyCode) else {
            return nil
        }

        guard normalizedCharacters(from: charactersIgnoringModifiers) != usKeyEquivalent else {
            return nil
        }

        return shortcutMatches(shortcutResolver: shortcutResolver)
            .first {
                $0.keyEquivalent == usKeyEquivalent && $0.modifiers == normalizedModifiers
            }?.command
    }

    // MARK: Private

    private struct ShortcutMatch {
        // MARK: Lifecycle

        init(
            command: BrowserLayoutIndependentShortcutCommand,
            keyEquivalent: String,
            modifiers: NSEvent.ModifierFlags
        ) {
            self.command = command
            self.keyEquivalent = keyEquivalent.lowercased()
            self.modifiers = modifiers.intersection(.deviceIndependentFlagsMask)
        }

        init(
            command: BrowserLayoutIndependentShortcutCommand,
            shortcut: BrowserKeyboardShortcut
        ) {
            self.init(
                command: command,
                keyEquivalent: shortcut.keyEquivalent,
                modifiers: shortcut.modifiers
            )
        }

        // MARK: Internal

        let command: BrowserLayoutIndependentShortcutCommand
        let keyEquivalent: String
        let modifiers: NSEvent.ModifierFlags
    }

    private static func shortcutMatches(shortcutResolver: BrowserShortcutResolving?) -> [ShortcutMatch] {
        var matches = [
            ShortcutMatch(command: .undo, keyEquivalent: "z", modifiers: [.command]),
            ShortcutMatch(command: .redo, keyEquivalent: "z", modifiers: [.command, .shift]),
            ShortcutMatch(command: .cut, keyEquivalent: "x", modifiers: [.command]),
            ShortcutMatch(command: .copy, keyEquivalent: "c", modifiers: [.command]),
            ShortcutMatch(command: .paste, keyEquivalent: "v", modifiers: [.command]),
            ShortcutMatch(command: .pasteAndMatchStyle, keyEquivalent: "v", modifiers: [.command, .shift]),
            ShortcutMatch(command: .selectAll, keyEquivalent: "a", modifiers: [.command]),
            ShortcutMatch(command: .quit, keyEquivalent: "q", modifiers: [.command]),
        ]

        matches.append(
            contentsOf: BrowserCommandID.allCases.map { commandID in
                ShortcutMatch(
                    command: commandID.layoutIndependentCommand,
                    shortcut: shortcutResolver?.shortcut(for: commandID) ?? commandID.defaultDescriptor.shortcut
                )
            }
        )
        return matches
    }

    private static func normalizedCharacters(from characters: String?) -> String? {
        characters?.lowercased()
    }

    private static func usKeyEquivalent(for keyCode: UInt16) -> String? {
        switch keyCode {
        case 0:
            "a"
        case 1:
            "s"
        case 2:
            "d"
        case 3:
            "f"
        case 5:
            "g"
        case 6:
            "z"
        case 7:
            "x"
        case 8:
            "c"
        case 9:
            "v"
        case 11:
            "b"
        case 12:
            "q"
        case 45:
            "n"
        case 13:
            "w"
        case 15:
            "r"
        case 16:
            "y"
        case 17:
            "t"
        case 35:
            "p"
        case 38:
            "j"
        case 40:
            "k"
        case 30:
            "]"
        case 33:
            "["
        case 43:
            ","
        default:
            nil
        }
    }
}
