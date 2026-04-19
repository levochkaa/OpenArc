import AppKit
import Foundation

struct BrowserKeyboardShortcut {
    let keyEquivalent: String
    let modifiers: NSEvent.ModifierFlags

    init(_ keyEquivalent: String, modifiers: NSEvent.ModifierFlags = [.command]) {
        self.keyEquivalent = keyEquivalent
        self.modifiers = modifiers
    }

    var keyCaps: [String] {
        var result: [String] = []

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
}

struct BrowserCommandDescriptor {
    let menuTitle: String
    let helpTitle: String
    let shortcut: BrowserKeyboardShortcut
}

enum BrowserCommands {
    static let openSettings = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuSettings,
        helpTitle: BrowserStrings.menuSettings,
        shortcut: BrowserKeyboardShortcut(",")
    )

    static let newTab = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuNewTab,
        helpTitle: BrowserStrings.sidebarNewTab,
        shortcut: BrowserKeyboardShortcut("t")
    )

    static let savePage = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuSavePageAs,
        helpTitle: BrowserStrings.menuSavePageAs,
        shortcut: BrowserKeyboardShortcut("s", modifiers: [.command, .shift])
    )

    static let copyLink = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.tabCopyLinkAction,
        helpTitle: BrowserStrings.tabCopyLinkAction,
        shortcut: BrowserKeyboardShortcut("c", modifiers: [.command, .shift])
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

    static let toggleSidebar = BrowserCommandDescriptor(
        menuTitle: BrowserStrings.menuToggleSidebar,
        helpTitle: BrowserStrings.sidebarHide,
        shortcut: BrowserKeyboardShortcut("s")
    )
}

enum BrowserLayoutIndependentShortcutCommand: Equatable {
    case undo
    case redo
    case cut
    case copy
    case paste
    case selectAll
    case quit
    case openSettings
    case newTab
    case savePage
    case copyLink
    case clearTemporaryTabs
    case goBack
    case goForward
    case reload
    case forceReload
    case toggleSidebar
}

enum BrowserKeyboardShortcutBridge {
    static func commandForLayoutIndependentDispatch(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        charactersIgnoringModifiers: String?
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

        return shortcutMatches.first {
            $0.keyEquivalent == usKeyEquivalent && $0.modifiers == normalizedModifiers
        }?.command
    }

    private struct ShortcutMatch {
        let command: BrowserLayoutIndependentShortcutCommand
        let keyEquivalent: String
        let modifiers: NSEvent.ModifierFlags

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
    }

    private static let shortcutMatches: [ShortcutMatch] = [
        ShortcutMatch(command: .undo, keyEquivalent: "z", modifiers: [.command]),
        ShortcutMatch(command: .redo, keyEquivalent: "z", modifiers: [.command, .shift]),
        ShortcutMatch(command: .cut, keyEquivalent: "x", modifiers: [.command]),
        ShortcutMatch(command: .copy, keyEquivalent: "c", modifiers: [.command]),
        ShortcutMatch(command: .paste, keyEquivalent: "v", modifiers: [.command]),
        ShortcutMatch(command: .selectAll, keyEquivalent: "a", modifiers: [.command]),
        ShortcutMatch(command: .quit, keyEquivalent: "q", modifiers: [.command]),
        ShortcutMatch(command: .openSettings, shortcut: BrowserCommands.openSettings.shortcut),
        ShortcutMatch(command: .newTab, shortcut: BrowserCommands.newTab.shortcut),
        ShortcutMatch(command: .savePage, shortcut: BrowserCommands.savePage.shortcut),
        ShortcutMatch(command: .copyLink, shortcut: BrowserCommands.copyLink.shortcut),
        ShortcutMatch(command: .clearTemporaryTabs, shortcut: BrowserCommands.clearTemporaryTabs.shortcut),
        ShortcutMatch(command: .goBack, shortcut: BrowserCommands.goBack.shortcut),
        ShortcutMatch(command: .goForward, shortcut: BrowserCommands.goForward.shortcut),
        ShortcutMatch(command: .reload, shortcut: BrowserCommands.reload.shortcut),
        ShortcutMatch(command: .forceReload, shortcut: BrowserCommands.forceReload.shortcut),
        ShortcutMatch(command: .toggleSidebar, shortcut: BrowserCommands.toggleSidebar.shortcut),
    ]

    private static func normalizedCharacters(from characters: String?) -> String? {
        characters?.lowercased()
    }

    private static func usKeyEquivalent(for keyCode: UInt16) -> String? {
        switch keyCode {
        case 0:
            "a"
        case 1:
            "s"
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
        case 15:
            "r"
        case 17:
            "t"
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

enum BrowserStrings {
    static let applicationName = NSLocalizedString(
        "browser.app.name",
        comment: "The localized application name."
    )

    static let newTabTitle = NSLocalizedString(
        "browser.tab.new",
        comment: "Fallback title for a new tab without page metadata."
    )

    static let sidebarNewTab = NSLocalizedString(
        "browser.sidebar.new_tab",
        comment: "Sidebar button title for creating a new tab."
    )

    static let sidebarHide = NSLocalizedString(
        "browser.sidebar.hide",
        comment: "Tooltip for hiding the sidebar."
    )

    static let navigationBack = NSLocalizedString(
        "browser.navigation.back",
        comment: "Title for back navigation actions."
    )

    static let navigationForward = NSLocalizedString(
        "browser.navigation.forward",
        comment: "Title for forward navigation actions."
    )

    static let navigationRefresh = NSLocalizedString(
        "browser.navigation.refresh",
        comment: "Title for refresh actions."
    )

    static let navigationStopLoading = NSLocalizedString(
        "browser.navigation.stop_loading",
        comment: "Title for stop loading actions."
    )

    static let loadingLaunchingBrowser = NSLocalizedString(
        "browser.loading.launching",
        comment: "Loading message shown while the browser initializes."
    )

    static let commandBarPlaceholder = NSLocalizedString(
        "browser.command_bar.placeholder",
        comment: "Placeholder shown in the command bar search field."
    )

    static let menuFile = NSLocalizedString(
        "browser.menu.file",
        comment: "File menu title."
    )

    static let menuEdit = NSLocalizedString(
        "browser.menu.edit",
        comment: "Edit menu title."
    )

    static let menuView = NSLocalizedString(
        "browser.menu.view",
        comment: "View menu title."
    )

    static let menuSettings = NSLocalizedString(
        "browser.menu.settings",
        comment: "Settings menu item title."
    )

    static let menuUndo = NSLocalizedString(
        "browser.menu.undo",
        comment: "Undo menu item title."
    )

    static let menuRedo = NSLocalizedString(
        "browser.menu.redo",
        comment: "Redo menu item title."
    )

    static let menuCut = NSLocalizedString(
        "browser.menu.cut",
        comment: "Cut menu item title."
    )

    static let menuCopy = NSLocalizedString(
        "browser.menu.copy",
        comment: "Copy menu item title."
    )

    static let menuPaste = NSLocalizedString(
        "browser.menu.paste",
        comment: "Paste menu item title."
    )

    static let menuSelectAll = NSLocalizedString(
        "browser.menu.select_all",
        comment: "Select All menu item title."
    )

    static let menuNewTab = NSLocalizedString(
        "browser.menu.new_tab",
        comment: "New Tab menu item title."
    )

    static let menuSavePageAs = NSLocalizedString(
        "browser.menu.save_page_as",
        comment: "Save Page As menu item title."
    )

    static let menuForceRefresh = NSLocalizedString(
        "browser.menu.force_refresh",
        comment: "Force Refresh menu item title."
    )

    static let menuToggleSidebar = NSLocalizedString(
        "browser.menu.toggle_sidebar",
        comment: "Toggle Sidebar menu item title."
    )

    static let menuClearTemporaryTabs = NSLocalizedString(
        "browser.menu.clear_temporary_tabs",
        comment: "Clear Temporary Tabs menu item title."
    )

    static let sidebarClearTemporaryTabs = NSLocalizedString(
        "browser.sidebar.clear_temporary_tabs",
        comment: "Button title for clearing temporary tabs."
    )

    static let sidebarClearTemporaryTabsTooltip = NSLocalizedString(
        "browser.sidebar.clear_temporary_tabs_tooltip",
        comment: "Tooltip shown for clearing temporary tabs."
    )

    static let tabArchiveAction = NSLocalizedString(
        "browser.tab.archive_action",
        comment: "Context menu title for archiving a tab."
    )

    static let tabArchiveTabsBelowAction = NSLocalizedString(
        "browser.tab.archive_tabs_below_action",
        comment: "Context menu title for archiving tabs below the current tab."
    )

    static let tabArchiveTooltip = NSLocalizedString(
        "browser.tab.archive_tooltip",
        comment: "Tooltip shown for archiving a tab."
    )

    static let tabCopyLinkAction = NSLocalizedString(
        "browser.tab.copy_link_action",
        comment: "Menu item title for copying a tab link."
    )

    static let tabRenameAction = NSLocalizedString(
        "browser.tab.rename_action",
        comment: "Context menu title for renaming a tab."
    )

    static let tabShareAction = NSLocalizedString(
        "browser.tab.share_action",
        comment: "Context menu title for sharing a tab."
    )

    static let tabRenameTooltipCaption = NSLocalizedString(
        "browser.tab.rename_tooltip_caption",
        comment: "Caption shown under the tab title tooltip."
    )

    static let settingsTemporaryTabsTitle = NSLocalizedString(
        "browser.settings.temporary_tabs.title",
        comment: "Title for the temporary tab settings section."
    )

    static let settingsGeneralTab = NSLocalizedString(
        "browser.settings.general",
        comment: "Title for the general settings tab."
    )

    static let settingsTemporaryTabsDescription = NSLocalizedString(
        "browser.settings.temporary_tabs.description",
        comment: "Description for the temporary tab settings section."
    )

    static let settingsTemporaryTabsLifetimeLabel = NSLocalizedString(
        "browser.settings.temporary_tabs.lifetime_label",
        comment: "Label for the temporary tab archival lifetime picker."
    )

    static let settingsLifetimeTwelveHours = NSLocalizedString(
        "browser.settings.temporary_tabs.lifetime.12h",
        comment: "Option title for archiving temporary tabs after 12 hours."
    )

    static let settingsLifetimeTwentyFourHours = NSLocalizedString(
        "browser.settings.temporary_tabs.lifetime.24h",
        comment: "Option title for archiving temporary tabs after 24 hours."
    )

    static let settingsLifetimeSevenDays = NSLocalizedString(
        "browser.settings.temporary_tabs.lifetime.7d",
        comment: "Option title for archiving temporary tabs after 7 days."
    )

    static let settingsLifetimeThirtyDays = NSLocalizedString(
        "browser.settings.temporary_tabs.lifetime.30d",
        comment: "Option title for archiving temporary tabs after 30 days."
    )

    static let notificationPermissionTitle = NSLocalizedString(
        "browser.permissions.notifications.title",
        comment: "Notification permission prompt title."
    )

    static let notificationPermissionAllow = NSLocalizedString(
        "browser.permissions.allow",
        comment: "Allow button title for notification permissions."
    )

    static let notificationPermissionDontAllow = NSLocalizedString(
        "browser.permissions.dont_allow",
        comment: "Don't Allow button title for notification permissions."
    )

    static func quitMenuItem(appName: String) -> String {
        String(
            format: NSLocalizedString(
                "browser.menu.quit",
                comment: "Quit menu item title with the app name placeholder."
            ),
            appName
        )
    }

    static func notificationPermissionMessage(origin: String) -> String {
        String(
            format: NSLocalizedString(
                "browser.permissions.notifications.message",
                comment: "Notification permission prompt body with the site origin placeholder."
            ),
            origin
        )
    }

    static func title(for lifetime: BrowserTemporaryTabLifetime) -> String {
        switch lifetime {
        case .twelveHours:
            settingsLifetimeTwelveHours
        case .twentyFourHours:
            settingsLifetimeTwentyFourHours
        case .sevenDays:
            settingsLifetimeSevenDays
        case .thirtyDays:
            settingsLifetimeThirtyDays
        }
    }
}
